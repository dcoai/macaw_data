defmodule Macaw.Data.Source.Push do
  @moduledoc """
  One push subscription, as a value (spec/01 §4).

  A source that supports `:push` sends its subscriber two messages, both tagged with the
  reference `subscribe/2` answered:

      {:macaw_source, ref, {:schema, schema}}      # first, and again when the schema changes
      {:macaw_source, ref, {:delivery, delivery}}  # an increment: the rows new since the last

  `schema_message/2` and `delivery_message/2` build them. The subscriber holds a `Push`
  in its state: `receive/2` takes each message (a schema is cached, a delivery buffered),
  and `drain/2` merges everything buffered since the last pulse at once, so a burst of
  pushes between two pulses costs one merge. `held/1` is the delivery as it stands.

  - **The handshake sends the schema first.** A delivery names its schema's version; one
    naming a version not yet cached falls back to `describe` (`drain/2`'s function, the
    `Macaw.Data.Schema.Cache.resolve/4` describe function), asked once and cached.
  - **An increment is merged by the window field:** its rows after what is held are
    appended; its late rows, at or before that, are kept unless the very row is held
    already; the rows stay ordered by the window field, the served window grown to cover
    them. A schema with no window field keeps the newest `limit` rows, marking the
    delivery `capped` when it drops any.

  It is not a process: the process that subscribes receives the messages in its mailbox
  and passes them here. Ported from the logic of visualize's `Visualize.Feed.Monitor`,
  whose message tag was `:visualize_feed`.
  """

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Schema.Cache

  @tag :macaw_source

  @enforce_keys [:name, :ref]
  defstruct [:name, :ref, held: nil, pending: [], cache: %Cache{}, errors: [], limit: 100_000]

  @type t :: %__MODULE__{
          name: term(),
          ref: reference(),
          held: Delivery.t() | nil,
          pending: [Delivery.t()],
          cache: Cache.t(),
          errors: [term()],
          limit: pos_integer()
        }

  @doc """
  A subscription to the source named `name` under `ref`, holding nothing yet. Options:
  `cache:` a `Schema.Cache` to start from, `limit:` the most rows held for a schema with
  no window field (`100_000`).
  """
  @spec new(term(), reference(), keyword()) :: t()
  def new(name, ref, opts \\ []) when is_reference(ref) do
    opts = Keyword.validate!(opts, cache: %Cache{}, limit: 100_000)
    %__MODULE__{name: name, ref: ref, cache: opts[:cache], limit: opts[:limit]}
  end

  @doc "The message a source sends with its schema, first and on every change."
  @spec schema_message(reference(), Schema.t()) :: tuple()
  def schema_message(ref, %Schema{} = schema), do: {@tag, ref, {:schema, schema}}

  @doc "The message a source sends with an increment."
  @spec delivery_message(reference(), Delivery.t()) :: tuple()
  def delivery_message(ref, %Delivery{} = delivery), do: {@tag, ref, {:delivery, delivery}}

  @doc """
  A message the subscriber received: `{:ok, push}` with a schema cached or a delivery
  buffered, `:ignore` for a message that is not this subscription's.
  """
  @spec receive(t(), term()) :: {:ok, t()} | :ignore
  def receive(%__MODULE__{ref: ref} = push, {@tag, ref, {:schema, %Schema{} = schema}}),
    do: {:ok, %{push | cache: Cache.put(push.cache, push.name, schema)}}

  def receive(%__MODULE__{ref: ref} = push, {@tag, ref, {:delivery, %Delivery{} = delivery}}),
    do: {:ok, %{push | pending: [delivery | push.pending]}}

  def receive(%__MODULE__{}, _message), do: :ignore

  @doc """
  Every buffered delivery merged into what is held, in the order received: one merge per
  pulse, whatever the push rate. A delivery naming a version the cache lacks is resolved
  through `describe` (`Schema.Cache.resolve/4`); one that cannot be is dropped and its
  reason kept in `errors`. A delivery naming no version is read under the held schema's.
  """
  @spec drain(t(), Cache.describe()) :: t()
  def drain(%__MODULE__{pending: pending} = push, describe) do
    pending
    |> Enum.reverse()
    |> Enum.reduce(%{push | pending: []}, fn delivery, push ->
      case resolve(push, delivery, describe) do
        {:ok, schema, push} -> %{push | held: merge(push.held, delivery, schema, push.limit)}
        {:error, reason, push} -> %{push | errors: push.errors ++ [reason]}
      end
    end)
  end

  @doc "The delivery as it stands, or `nil` before the first."
  @spec held(t()) :: Delivery.t() | nil
  def held(%__MODULE__{held: held}), do: held

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
    do: merge(%{delivery | table: empty(delivery.table)}, delivery, schema, limit)

  defp merge(held, delivery, schema, limit) do
    old = Delivery.rows(held)
    new = Delivery.rows(delivery)
    version = delivery.schema || held.schema

    case Schema.window_field(schema) do
      nil ->
        all = old ++ new
        cut = max(length(all) - limit, 0)
        served = %{held.served | capped: held.served.capped or cut > 0}
        %{rebuild(held, Enum.drop(all, cut), delivery) | schema: version, served: served}

      time ->
        held_to = window_to(held) || newest(old, time)
        newer = Window.newer(new, time, held_to)
        late = late(old, new, time, held_to)
        rows = ordered(old ++ late ++ newer, time)
        to = Window.latest(held_to, window_to(delivery) || newest(newer, time))
        from = window_from(held) || window_from(delivery) || earliest(rows, time)
        served = %{held.served | window: [from, to]}
        %{rebuild(held, rows, delivery) | schema: version, served: served}
    end
  end

  # The pushed rows at or before what is held that it does not hold already.
  defp late(_old, _new, _time, nil), do: []

  defp late(old, new, time, held_to) do
    case Enum.filter(new, &late?(Table.get(&1, time), held_to)) do
      [] -> []
      late -> late |> Enum.reject(&(&1 in old)) |> Enum.uniq()
    end
  end

  defp late?(t, held_to) do
    case {Window.position(t), Window.position(held_to)} do
      {nil, _held} -> false
      {_t, nil} -> false
      {t, held} -> t <= held
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

  defp empty(table), do: Table.slice(table, 0, 0)

  # The held columns, and any the increment adds, of their types.
  defp rebuild(held, rows, delivery) do
    types =
      Enum.reduce([held.table, delivery.table], %{}, fn table, acc ->
        Enum.reduce(Table.names(table), acc, &Map.put_new(&2, &1, Table.column_type(table, &1)))
      end)

    names = Table.names(held.table) ++ (Table.names(delivery.table) -- Table.names(held.table))
    columns = for name <- names, do: {name, types[name], Enum.map(rows, &Map.get(&1, name))}
    %{held | table: Table.new!(columns)}
  end
end
