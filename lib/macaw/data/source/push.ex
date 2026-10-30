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
  - **An increment's rows are insertions, merged by the window field:** they stay
    ordered by it, a late row placed among the held, and the served window grows to
    cover them. Rows are never deduplicated: an identical row is a second row. A schema
    with no window field keeps the newest `limit` rows, marking the delivery `capped`
    when it drops any.

  It is not a process: the process that subscribes receives the messages in its mailbox
  and passes them here. Ported from the logic of visualize's `Visualize.Feed.Monitor`,
  whose message tag was `:visualize_feed`.
  """

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Schema.Cache

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
    refetch: nil
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
          refetch: term()
        }

  @doc """
  A subscription to the source named `name` under `ref`, holding nothing yet, at
  position `0`. Options: `cache:` a `Schema.Cache` to start from, `limit:` the most rows
  held for a schema with no window field (`100_000`).
  """
  @spec new(term(), reference(), keyword()) :: t()
  def new(name, ref, opts \\ []) when is_reference(ref) do
    opts = Keyword.validate!(opts, cache: %Cache{}, limit: 100_000)
    %__MODULE__{name: name, ref: ref, cache: opts[:cache], limit: opts[:limit]}
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
  kept in `errors`. A delivery naming no version is read under the held schema's.
  """
  @spec drain(t(), Cache.describe()) :: t()
  def drain(%__MODULE__{pending: pending} = push, describe) do
    pending
    |> Enum.reverse()
    |> Enum.reduce(%{push | pending: []}, &take(&2, &1, describe))
    |> gap()
  end

  @doc "The relation as it stands, a delivery, or `nil` before anything is held."
  @spec held(t()) :: Delivery.t() | nil
  def held(%__MODULE__{held: held}), do: held

  @doc """
  `nil`, or why the holder must fetch a snapshot for this subscription and hand it to
  `snapshot/2` (spec/01 §4.1): `{:gap, from, to}`, the numbers that never arrived. A
  snapshot taken clears it.
  """
  @spec refetch(t()) :: term()
  def refetch(%__MODULE__{refetch: refetch}), do: refetch

  # -- the handoff (spec/01 §4.1) ---------------------------------------------------------

  defp take(push, {:snapshot, %Delivery{served: %{position: nil}}}, _describe),
    do: fault(push, {:snapshot, :no_position})

  defp take(%{position: held} = push, {:snapshot, %Delivery{served: %{position: p}}}, _describe)
       when p < held,
       do: ignore(push, :stale_snapshot)

  defp take(push, {:snapshot, %Delivery{served: %{position: p}} = delivery}, describe) do
    case resolve(push, delivery, describe) do
      {:ok, _schema, push} ->
        waiting = Map.reject(push.waiting, fn {seq, _d} -> seq <= p end)
        advance(%{push | held: delivery, position: p, waiting: waiting, refetch: nil}, describe)

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

  # After a drain, increments still held back mean a gap: recorded once, and answered.
  defp gap(%{waiting: waiting, position: held} = push) when map_size(waiting) > 0 do
    gap = {:gap, held + 1, Enum.min(Map.keys(waiting)) - 1}

    if push.refetch == gap,
      do: push,
      else: %{push | refetch: gap, errors: push.errors ++ [gap]}
  end

  defp gap(%{refetch: {:gap, _from, _to}} = push), do: %{push | refetch: nil}
  defp gap(push), do: push

  defp apply_increment(push, seq, delivery, describe) do
    push = %{push | position: seq}

    case resolve(push, delivery, describe) do
      {:ok, schema, push} -> %{push | held: merge(push.held, delivery, schema, push.limit)}
      {:error, reason, push} -> fault(push, reason)
    end
  end

  defp fault(push, reason), do: %{push | errors: push.errors ++ [reason]}

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

  defp merge(nil, delivery, schema, limit),
    do: merge(%{delivery | rows: empty(delivery.rows)}, delivery, schema, limit)

  defp merge(held, delivery, schema, limit) do
    old = Delivery.named_rows(held)
    new = Delivery.named_rows(delivery)
    version = delivery.schema || held.schema

    case Schema.window_field(schema) do
      nil ->
        all = old ++ new
        cut = max(length(all) - limit, 0)
        served = %{held.served | capped: held.served.capped or cut > 0}
        %{rebuild(held, Enum.drop(all, cut), delivery) | schema: version, served: served}

      time ->
        # Every pushed row is an insertion, a late one placed among the held: an
        # identical row is a second row, never deduplicated (spec/01 §4.1).
        held_to = window_to(held) || newest(old, time)
        rows = ordered(old ++ new, time)
        to = Window.latest(held_to, window_to(delivery) || newest(new, time))
        from = window_from(held) || window_from(delivery) || earliest(rows, time)
        served = %{held.served | window: [from, to]}
        %{rebuild(held, rows, delivery) | schema: version, served: served}
    end
  end

  # Stable by the window field's position, a row with no time last.
  defp ordered(rows, time) do
    Enum.sort_by(rows, fn row ->
      case Window.position(Table.get(row, time)) do
        nil -> {1, 0}
        p -> {0, p}
      end
    end)
  end

  defp window_from(%Delivery{served: %{window: [from, _to]}}), do: from
  defp window_from(_delivery), do: nil

  defp window_to(%Delivery{served: %{window: [_from, to]}}), do: to
  defp window_to(_delivery), do: nil

  defp newest(rows, time), do: Enum.reduce(rows, nil, &Window.latest(&2, Table.get(&1, time)))
  defp earliest(rows, time), do: Enum.reduce(rows, nil, &Window.earliest(&2, Table.get(&1, time)))

  defp empty(%Table{} = table), do: Table.slice(table, 0, 0)
  defp empty(_rows), do: []

  # What is held, in the form the source gave it: when both are tables, the held columns
  # and any the increment adds, of their types; else the rows themselves (macaw#185).
  defp rebuild(%Delivery{rows: %Table{} = held_table} = held, rows, %Delivery{
         rows: %Table{} = table
       }) do
    types =
      Enum.reduce([held_table, table], %{}, fn table, acc ->
        Enum.reduce(Table.names(table), acc, &Map.put_new(&2, &1, Table.column_type(table, &1)))
      end)

    names = Table.names(held_table) ++ (Table.names(table) -- Table.names(held_table))
    columns = for name <- names, do: {name, types[name], Enum.map(rows, &Map.get(&1, name))}
    %{held | rows: Table.new!(columns)}
  end

  defp rebuild(held, rows, _delivery), do: %{held | rows: rows, names: nil}
end
