defmodule Macaw.Data.Source.Conformance.Pushes do
  @moduledoc false
  # The push and unsubscribe checks' clauses (spec/01 §4, §9): the kit's own process
  # subscribed, the source made to push, and the messages held to the handshake and the
  # schemas they name. Ported from visualize's `Visualize.Feed.Conformance`.

  alias Macaw.Data.{Delivery, Schema, Source}
  alias Macaw.Data.Source.Request
  alias Macaw.Data.Source.Conformance.{Call, Deliveries}

  @doc false
  # The kit's own process subscribed: `{:ok, ref}` or the findings.
  def subscribed(source, o) do
    me = self()

    case call(fn -> Source.subscribe(source, me) end, :subscribe, o) do
      {:ok, {:ok, ref}} when is_reference(ref) -> {:ok, ref}
      {:ok, {:error, reason}} -> [{:subscribe_error, reason}]
      {:ok, other} -> [{:not_a_value, :subscribe, other}]
      {:error, fault} -> [fault]
    end
  end

  @doc false
  def unsubscribed(source, ref, o) do
    case call(fn -> Source.unsubscribe(source, ref) end, :unsubscribe, o) do
      {:ok, :ok} -> []
      {:ok, other} -> [{:unsubscribe, other}]
      {:error, fault} -> [fault]
    end
  end

  @doc false
  # The `push:` function run; `[]`, or the findings of a raise or a hang.
  def stimulate(_source, %{push: nil}), do: [{:no_probe, :push}]

  def stimulate(source, %{push: push} = o) do
    case call(fn -> push.(source) end, :push, o) do
      {:ok, _any} -> []
      {:error, fault} -> [fault]
    end
  end

  @doc false
  # The messages under a reference, in arrival order: until the deadline while no delivery
  # has arrived, then until `quiet` passes with none.
  def collect(ref, deadline, quiet, delivered?, acc) do
    wait = if delivered?, do: quiet, else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:macaw_source, ^ref, message} ->
        delivered? = delivered? or match?({:increment, _, _}, message)
        collect(ref, deadline, quiet, delivered?, [message | acc])
    after
      wait -> Enum.reverse(acc)
    end
  end

  @doc false
  def flush(ref) do
    receive do
      {:macaw_source, ^ref, _message} -> flush(ref)
    after
      0 -> :ok
    end
  end

  @doc false
  # The subscription's snapshot fetched as a holder fetches it on handoff (spec/01 §4.1):
  # the first request, no budget, naming the subscription. `{:ok, resolution, position}`,
  # its `served.resolution` and `served.position`, or the findings of a fetch that answers
  # no delivery.
  def subscribed_fetch(source, description, ref, o) do
    ask = List.first(o.requests) || []
    probe = {:subscribed, ask}

    with {:ok, request} <- subscribed_request(ask, ref, o),
         {:ok, {:ok, %Delivery{served: served}}} when is_map(served) <-
           call(fn -> Source.fetch(source, description, request) end, {:fetch, probe}, o) do
      {:ok, Map.get(served, :resolution), Map.get(served, :position)}
    else
      {:error, {:request, faults}} -> [{:probe, ask, faults}]
      {:ok, {:error, {:bad_fetch, other}}} -> [{:not_a_delivery, probe, other}]
      {:ok, {:error, reason}} -> [{:fetch_error, probe, reason}]
      {:ok, other} -> [{:not_a_delivery, probe, other}]
      {:error, fault} -> [fault]
    end
  end

  defp subscribed_request(ask, ref, o) do
    case Request.new(ask ++ [now: o.now, viewer: hd(o.viewers), subscription: ref]) do
      {:ok, request} -> {:ok, request}
      {:error, faults} -> {:error, {:request, faults}}
    end
  end

  @doc false
  # The handshake first, then every delivery after the schema it names; a snapshot
  # stating its position, and the increments numbered one past it, or from 1 with none,
  # each one past the last (spec/01 §4.1); and every increment at the resolution of the
  # subscription's first snapshot (§4.3). `before` arrived before the subscription's own
  # fetch, whose answer `fetched` is (`{:ok, resolution, position}`, or findings), and
  # `messages` after it: the first snapshot in that order fixes the resolution. The
  # fetched snapshot states its position as a pushed one does (§3, §4.1), and the
  # increments after it are numbered past it; one older than what is numbered already is
  # stale, which a holder drops, so the numbering goes on from the later of the two.
  def sequence(handshake, before, fetched, messages, o) do
    {known, faults} =
      case handshake do
        {:schema, %Schema{} = schema} -> {%{schema.version => schema}, pushed_schema(schema)}
        other -> {%{}, [{:handshake, other}]}
      end

    state = %{known: known, next: 1, faults: faults, delivered?: false, held: nil}
    state = Enum.reduce(before, state, &message(&1, &2, o))

    state =
      case fetched do
        {:ok, resolution, p} when is_integer(p) and p >= 0 ->
          %{held(state, resolution) | next: max(state.next, p + 1)}

        {:ok, resolution, p} ->
          state = held(state, resolution)
          %{state | faults: state.faults ++ [{:subscribed_position, p}]}

        findings ->
          %{state | faults: state.faults ++ findings}
      end

    state = Enum.reduce(messages, state, &message(&1, &2, o))

    if state.delivered?,
      do: state.faults,
      else: state.faults ++ [{:no_delivery, o.timeout}]
  end

  defp message({:schema, %Schema{} = schema}, state, _o) do
    %{
      state
      | known: Map.put(state.known, schema.version, schema),
        faults: state.faults ++ pushed_schema(schema)
    }
  end

  defp message({:snapshot, %Delivery{served: %{position: p}} = delivery}, state, o) do
    state = held(state, delivery.served.resolution)
    faults = state.faults ++ pushed_delivery(delivery, state.known, o)

    if is_integer(p),
      do: %{state | next: p + 1, faults: faults},
      else: %{state | faults: faults ++ [{:snapshot_position, p}]}
  end

  defp message({:increment, seq, %Delivery{} = delivery}, state, o) do
    numbering = if seq == state.next, do: [], else: [{:numbering, state.next, seq}]

    faults =
      state.faults ++
        numbering ++
        resolution(state.held, delivery.served.resolution) ++
        pushed_delivery(delivery, state.known, o)

    %{state | next: next_after(seq, state.next), faults: faults, delivered?: true}
  end

  defp message(other, state, _o), do: %{state | faults: state.faults ++ [{:not_a_message, other}]}

  # The first snapshot's resolution is the subscription's; a later one changes nothing.
  defp held(%{held: nil} = state, resolution), do: %{state | held: {:held, resolution}}
  defp held(state, _resolution), do: state

  # An increment at another resolution than the subscription's (`nil` equal only to `nil`),
  # which every holder refuses (spec/01 §4.3); none to compare with before a snapshot.
  defp resolution({:held, expected}, got) when expected !== got,
    do: [{:resolution, expected, got}]

  defp resolution(_held, _got), do: []

  defp next_after(seq, next) when is_integer(seq), do: max(seq, next - 1) + 1
  defp next_after(_seq, next), do: next

  defp pushed_schema(%Schema{} = schema) do
    case Deliveries.schema_faults(schema) do
      [] -> []
      [{:version, given, computed}] -> [{:schema_message, given, computed}]
      faults -> faults
    end
  end

  defp pushed_delivery(%Delivery{} = delivery, known, o) do
    {faults, rows} = Deliveries.well_formed(delivery, :push, o)

    case Map.fetch(known, delivery.schema) do
      {:ok, schema} when faults == [] ->
        Deliveries.outside(rows, :push, Schema.window_field(schema), delivery.served.window)

      {:ok, _schema} ->
        faults

      :error ->
        faults ++ [{:before_schema, delivery.schema}]
    end
  end

  @doc false
  # Subscribed, the handshake taken, unsubscribed: nothing more arrives.
  def silenced(source, o) do
    with {:ok, ref} <- subscribed(source, o) do
      flush(ref)
      answer = unsubscribed(source, ref, o)
      pushed = stimulate(source, o)
      after_ = collect(ref, System.monotonic_time(:millisecond) + o.quiet, o.quiet, true, [])
      flush(ref)

      answer ++
        pushed ++
        if(after_ == [], do: [], else: [{:pushed_after_unsubscribe, length(after_)}])
    end
  end

  defp call(fun, call, o), do: Call.run(fun, call, o)
end
