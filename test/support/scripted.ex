defmodule Macaw.Data.Test.Scripted do
  @moduledoc """
  A source whose every answer comes from an `Agent` the test holds (ported from
  visualize's `Visualize.Test.Feeds.Scripted`), so a test can change what it says between
  ticks and count how often it was asked.

  The agent holds `schema`, `supports`, `rows` (or a function of the request answering a
  delivery's rows and its served facts, `schema:` among them for another version),
  `error` (answered by every call when set), `ref` (the subscription reference it
  answers), `seq` (the last increment it pushed), `chunk_span` and `lateness` (its
  description's) and `calls`, a count by callback. A fetch under its subscription states
  its position, the last increment it pushed, unless the function's facts state one.
  """
  @behaviour Macaw.Data.Source

  alias Macaw.Data.{Delivery, Schema}
  alias Macaw.Data.Source.{Description, Push, Request}

  @enforce_keys [:agent]
  defstruct [:agent]

  @doc "A scripted source and its agent, linked to the caller."
  def new(opts) do
    state = %{
      schema: Keyword.fetch!(opts, :schema),
      supports: Keyword.get(opts, :supports, []),
      rows: Keyword.get(opts, :rows, []),
      error: Keyword.get(opts, :error),
      ref: nil,
      seq: 0,
      chunk_span: Keyword.get(opts, :chunk_span),
      lateness: Keyword.get(opts, :lateness),
      calls: %{},
      requests: []
    }

    {:ok, agent} = Agent.start_link(fn -> state end)
    {%__MODULE__{agent: agent}, agent}
  end

  @doc "How many times a callback ran."
  def calls(agent, call), do: Agent.get(agent, &Map.get(&1.calls, call, 0))

  @doc "Every request it was fetched with, the latest first."
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @doc "Its agent changed."
  def set(agent, changes), do: Agent.update(agent, &Map.merge(&1, Map.new(changes)))

  @doc "The subscription reference it answered."
  def ref(agent), do: Agent.get(agent, & &1.ref)

  @doc "A delivery pushed to `pid` under its subscription, numbered one past the last."
  def push(agent, pid, %Delivery{} = delivery) do
    {ref, seq} = Agent.get_and_update(agent, &{{&1.ref, &1.seq + 1}, %{&1 | seq: &1.seq + 1}})
    send(pid, Push.increment_message(ref, seq, delivery))
    :ok
  end

  @doc "A schema pushed to `pid` under its subscription."
  def push_schema(agent, pid, %Schema{} = schema) do
    send(pid, Push.schema_message(ref(agent), schema))
    :ok
  end

  @doc "Every source message in the mailbox handed to a monitor, in arrival order."
  def drain(monitor) do
    receive do
      {:macaw_source, _ref, _message} = message ->
        {:ok, monitor} = Macaw.Data.Monitor.handle_message(monitor, message)
        drain(monitor)
    after
      0 -> monitor
    end
  end

  @impl true
  def describe(%__MODULE__{agent: agent}, _context) do
    state = counted(agent, :describe)

    case state.error do
      nil ->
        {:ok,
         %Description{
           schema: state.schema,
           supports: state.supports,
           chunk_span: state.chunk_span,
           lateness: state.lateness
         }}

      error ->
        {:error, error}
    end
  end

  @impl true
  def fetch(%__MODULE__{agent: agent}, %Request{} = request) do
    state = counted(agent, :fetch, request)

    case state.error do
      nil -> delivery(state, request)
      error -> {:error, error}
    end
  end

  @impl true
  def subscribe(%__MODULE__{agent: agent}, pid) do
    state = counted(agent, :subscribe)

    case state.error do
      nil ->
        ref = state.ref || make_ref()
        Agent.update(agent, &%{&1 | ref: ref, seq: 0})
        send(pid, Push.schema_message(ref, state.schema))
        {:ok, ref}

      error ->
        {:error, error}
    end
  end

  @impl true
  def unsubscribe(%__MODULE__{agent: agent}, _ref) do
    counted(agent, :unsubscribe)
    :ok
  end

  defp delivery(%{rows: rows} = state, request) when is_function(rows, 1) do
    {rows, facts} = rows.(request)
    {schema, served} = Keyword.pop(facts, :schema, Schema.version(state.schema))
    served = Keyword.put_new(served, :position, position(state, request))
    Delivery.new(rows, served: served, schema: schema)
  end

  defp delivery(state, request) do
    Delivery.new(state.rows,
      served: [position: position(state, request)],
      schema: Schema.version(state.schema)
    )
  end

  defp position(%{ref: ref, seq: seq}, %Request{subscription: ref}) when ref != nil, do: seq
  defp position(_state, _request), do: nil

  defp counted(agent, call, request \\ nil) do
    Agent.get_and_update(agent, fn state ->
      state = update_in(state.calls[call], &((&1 || 0) + 1))
      state = if request, do: %{state | requests: [request | state.requests]}, else: state
      {state, state}
    end)
  end
end
