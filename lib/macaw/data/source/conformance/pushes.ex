defmodule Macaw.Data.Source.Conformance.Pushes do
  @moduledoc false
  # The push and unsubscribe checks' clauses (spec/01 §4, §9): the kit's own process
  # subscribed, the source made to push, and the messages held to the handshake and the
  # schemas they name. Ported from visualize's `Visualize.Feed.Conformance`.

  alias Macaw.Data.{Delivery, Schema, Source}
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
        delivered? = delivered? or match?({:delivery, _}, message)
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
  # The handshake first, then every delivery after the schema it names.
  def sequence(handshake, messages, o) do
    {known, faults} =
      case handshake do
        {:schema, %Schema{} = schema} -> {%{schema.version => schema}, pushed_schema(schema)}
        other -> {%{}, [{:handshake, other}]}
      end

    {_known, faults, delivered?} =
      Enum.reduce(messages, {known, faults, false}, fn
        {:schema, %Schema{} = schema}, {known, faults, delivered?} ->
          {Map.put(known, schema.version, schema), faults ++ pushed_schema(schema), delivered?}

        {:delivery, %Delivery{} = delivery}, {known, faults, _delivered?} ->
          {known, faults ++ pushed_delivery(delivery, known, o), true}

        other, {known, faults, delivered?} ->
          {known, faults ++ [{:not_a_message, other}], delivered?}
      end)

    if delivered?, do: faults, else: faults ++ [{:no_delivery, o.timeout}]
  end

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
