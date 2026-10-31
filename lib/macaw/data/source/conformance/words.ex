defmodule Macaw.Data.Source.Conformance.Words do
  @moduledoc false
  # The findings of spec/01 §9 in words, for `Macaw.Data.Source.Conformance.format/1`.
  # Ported from visualize's `Visualize.Feed.Conformance.Words`.

  alias Macaw.Data.Schema
  alias Macaw.Data.Source.{Description, Request}

  @doc false
  def words({:raised, call, reason}),
    do:
      "#{call(call)} raised or exited instead of answering a value: #{Exception.format_exit(reason)}"

  def words({:hung, call, timeout}),
    do: "#{call(call)} did not answer within #{timeout} ms: it is blocked (hung), not slow"

  def words({:reductions, call, spent, budget}),
    do: "#{call(call)} spent #{spent} reductions, over its budget of #{budget}"

  def words({:describe_error, reason}), do: "describe/2 answered {:error, #{inspect(reason)}}"

  def words({:not_described, answer}),
    do: "describe/2 answered #{inspect(answer)}, not {:ok, %Description{}} with a schema"

  def words({:description_invalid, faults}),
    do: "the description is not one Description.new/1 accepts as it stands: #{inspect(faults)}"

  def words({:schema_invalid, errors}),
    do:
      "the schema is not one Schema.new/1 accepts: #{Enum.map_join(errors, "; ", &Schema.format_error/1)}"

  def words({:measure, field, reason}),
    do:
      "the schema's field #{inspect(field)} names a measure the vocabulary refuses: " <>
        Schema.format_error({[field, key(reason)], reason})

  def words({:version, given, computed}) when is_binary(computed),
    do: "the version #{inspect(given)} is not the schema's content hash #{inspect(computed)}"

  def words({:unstable, first, second}),
    do:
      "a second describe answered another description (schema version #{inspect(second)}, " <>
        "the first #{inspect(first)})"

  def words({:no_window_field, capability, type}),
    do:
      "the source names #{inspect(capability)} but its window field is #{inspect(type)}; " <>
        "a :window is over a :time or :number field and a :box over a :point one, said window: true"

  def words({:probe, ask, faults}),
    do:
      "the probe #{inspect(ask)} is not a request the source's schema can answer " <>
        "(#{inspect(faults)}); the kit's requests: are the run's to fix"

  def words({:fetch_error, probe, reason}),
    do: "#{probe(probe)} answered {:error, #{inspect(reason)}}"

  def words({:not_a_delivery, probe, answer}),
    do: "#{probe(probe)} answered #{inspect(answer)}, not {:ok, %Delivery{}}"

  def words({:malformed, probe, field, value}),
    do: "#{probe(probe)}: the delivery's #{field} is not one: #{inspect(value)}"

  def words({:version, probe, named, described}),
    do:
      "#{probe(probe)}: the delivery names the version #{inspect(named)}, describe answered #{inspect(described)}"

  def words({:undescribed_field, probe, field}),
    do: "#{probe(probe)}: a row holds #{inspect(field)}, which the schema does not describe"

  def words({:window_value, probe, value}),
    do:
      "#{probe(probe)}: a row's window field holds #{inspect(value)}, not a value of its type " <>
        "(an instant for :time, a number for :number, {longitude, latitude} for :point)"

  def words({:no_identity, probe, field}),
    do:
      "#{probe(probe)}: a row has no value for #{inspect(field)}, which the schema " <>
        "declares part of its identity; every row says what it is about"

  def words({:not_an_instant, probe, field, value}),
    do:
      "#{probe(probe)}: the :time field #{inspect(field)} holds #{inspect(value)}, not an " <>
        "instant; a count or a tick is a :number"

  def words({:outside_served, probe, time, served}),
    do:
      "#{probe(probe)}: a row at #{inspect(time)} lies outside the served window #{inspect(served)}"

  def words({:missing, probe, count, served}),
    do:
      "#{probe(probe)}: the delivery says it served #{inspect(served)}, but #{rows(count)} the source holds there are missing"

  def words({:capped, probe, served}),
    do:
      "#{probe(probe)}: capped is true, but the served window #{inspect(served)} reaches the asked from"

  def words({:uncapped, probe, count}),
    do:
      "#{probe(probe)}: capped is false, but the source holds #{rows(count)} in the asked window before where it served from"

  def words({:reduced_by, probe, by}),
    do: "#{probe(probe)}: reduced_by is #{inspect(by)}, which is not true of this delivery"

  def words({:unrecorded_reduction, probe, count, whole}),
    do: "#{probe(probe)}: served #{count} rows of #{whole} with reduced_by nil"

  def words({:resolution, probe, gap, resolution}),
    do:
      "#{probe(probe)}: two rows of one series #{inspect(gap)} apart, finer than the resolution #{inspect(resolution)}"

  def words({:supports, supports}),
    do:
      "supports #{inspect(supports)} is not a list of distinct members of #{inspect(Description.capabilities())}"

  def words({:no_probe, :window}),
    do: "the source names :window, and requests: has none with a bounded window to probe it"

  def words({:no_probe, :box}),
    do: "the source names :box, and requests: has none with a box to probe it"

  def words({:no_probe, :region}),
    do: "the source names :region, and requests: has none with a region to probe it"

  def words({:no_probe, :latest}),
    do: "the source names :latest, and requests: has none with latest: true to probe it"

  def words({:no_probe, :order}),
    do: "the source names :order, and requests: has none with an order to probe it"

  def words({:no_probe, :budget}),
    do: "the source names :budget, and budgets: has none to probe it"

  def words({:no_probe, :push}),
    do: "the source names :push, and there is no push: function to make it push"

  def words({:window_served, probe, served}),
    do:
      "#{probe(probe)}: the source names :window and served #{inspect(served)}, not within the window asked"

  def words({:window_row, probe, time}),
    do:
      "#{probe(probe)}: the source names :window and served a row at #{inspect(time)}, outside the window asked"

  def words({:box_row, probe, position}),
    do:
      "#{probe(probe)}: the source names :box and served a row at #{inspect(position)}, outside the box asked"

  def words({:over_budget, probe, count}),
    do:
      "asked for at most #{elem(probe, 1)} rows (#{probe(probe)}), the source names :budget and served #{count}"

  def words({:region_row, probe, field, value}),
    do:
      "#{probe(probe)}: the source names :region and served a row whose #{inspect(field)} " <>
        "is #{inspect(value)}, outside the range asked"

  def words({:latest_twice, probe, identity}),
    do:
      "#{probe(probe)}: the source names :latest and served more than one row of #{inspect(identity)}"

  def words({:not_latest, probe, identity}),
    do:
      "#{probe(probe)}: the source names :latest and served a row of #{inspect(identity)} " <>
        "older than its last for the rest of the request"

  def words({:order_unstated, probe, ordered}),
    do:
      "#{probe(probe)}: the source names :order and served ordered: #{inspect(ordered)}, " <>
        "not :source"

  def words({:not_ordered, probe}),
    do: "#{probe(probe)}: the source names :order and served its rows out of the order asked"

  def words({:not_first, probe}),
    do:
      "#{probe(probe)}: the source names :order and served rows that are not the first in " <>
        "the order of its answer without a budget"

  def words({:ordered, probe, by}),
    do:
      "#{probe(probe)}: ordered is #{inspect(by)}, which only Macaw states, when it orders " <>
        "the rows itself (spec/01 §2.4)"

  def words({:as_of_origin, probe, as_of}),
    do:
      "#{probe(probe)}: the source names :as_of, and its delivery's origin is as of #{inspect(as_of)}, not the instant asked"

  def words({:as_of_moved, probe}),
    do:
      "#{probe(probe)}: the source names :as_of, and an hour's later now changed the answer as of the same instant"

  def words({:answer_moved, probe}),
    do:
      "#{probe(probe)}: asked twice with one now, the source answered twice differently; " <>
        "an answer depends on the request, never on a clock the source reads"

  def words({:viewer_dependent, probe}),
    do:
      "#{probe(probe)}: the source declares itself viewer independent, and two viewers got different answers"

  def words({:push_refused, reason}),
    do: "the source names :push, and subscribe/2 answered {:error, #{inspect(reason)}}"

  def words({:push_undeclared, answer}),
    do: "the source does not name :push, and subscribe/2 answered #{inspect(answer)}"

  def words({:subscribe_error, reason}), do: "subscribe/2 answered {:error, #{inspect(reason)}}"

  def words({:handshake, got}),
    do: "the first message after subscribe/2 was #{inspect(got)}, not the schema"

  def words({:schema_message, version, computed}),
    do:
      "a pushed schema's version #{inspect(version)} is not its content hash #{inspect(computed)}"

  def words({:numbering, expected, got}),
    do:
      "a pushed increment is numbered #{inspect(got)}, not #{expected}: increments are numbered " <>
        "from 1, or one past a snapshot's position, each one past the last"

  def words({:snapshot_position, got}),
    do:
      "a pushed snapshot states the position #{inspect(got)}, not the number of the last " <>
        "increment it reflects (served.position)"

  def words({:before_schema, version}),
    do: "a delivery naming #{inspect(version)} arrived before that version's schema"

  def words({:not_a_message, message}),
    do: "a message that is neither a schema nor a delivery: #{inspect(message)}"

  def words({:no_delivery, timeout}),
    do: "push: ran and no delivery arrived within #{timeout} ms"

  def words({:params_accepted, answer}),
    do:
      "a request with an undeclared parameter answered #{inspect(answer)}, not {:error, {:params, faults}}"

  def words({:not_a_value, call, answer}),
    do: "#{call(call)} answered #{inspect(answer)}, neither its success nor {:error, reason}"

  def words({:answered_down, call, answer}),
    do: "the down: source answered #{call(call)} with #{inspect(answer)}, not an error"

  def words({:unsubscribe, answer}), do: "unsubscribe/2 answered #{inspect(answer)}, not :ok"

  def words({:pushed_after_unsubscribe, count}),
    do: "#{count} message(s) arrived after unsubscribe/2"

  def words(other), do: inspect(other)

  defp call({:fetch, {:unreadable, %Request{} = request}}),
    do: "fetch of #{inspect(asked(request))}"

  defp call({:fetch, probe}), do: probe(probe)
  defp call(:describe), do: "describe/2"
  defp call(:subscribe), do: "subscribe/2"
  defp call(:unsubscribe), do: "unsubscribe/2"
  defp call(:push), do: "the push: function"
  defp call(:rows), do: "reading the rows"

  # The fields an unreadable request sets, beside its now and viewer.
  defp asked(%Request{} = request) do
    defaults = Map.from_struct(%Request{now: request.now})

    for {key, value} <- Map.from_struct(request),
        key not in [:now, :viewer],
        value != defaults[key],
        do: {key, value}
  end

  defp rows(1), do: "1 row"
  defp rows(n), do: "#{n} rows"

  defp probe(:push), do: "a pushed delivery"
  defp probe({ask, nil}), do: "fetch #{inspect(ask)}"
  defp probe({ask, budget}), do: "fetch #{inspect(ask)} with budget #{budget}"

  # The key a measure's fault is at.
  defp key({:unit, _code, _reason}), do: :unit
  defp key(_quantity_fault), do: :quantity
end
