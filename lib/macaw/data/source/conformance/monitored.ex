defmodule Macaw.Data.Source.Conformance.Monitored do
  @moduledoc false
  # The kit's `:monitor` check (spec/01 §9): the source run through a `Macaw.Data.Monitor`,
  # as a page runs it. Each probe is one reader of the source: one tick makes it `:live`,
  # and its delivery is the source's answer finished for that reader alone, every row of
  # it when the probe asks no budget, and under a budget as many rows, each one the
  # answer holds. A source naming `:push`, with `push:` given, keeps its reader live with
  # no error once the push is drained, and the push grows what the monitor holds.
  #
  # Each probe runs in one process of its own (`Conformance.Call`), so the monitor's
  # owner, which the source pushes to, is the process that ticks it.

  alias Macaw.Data.{Delivery, Monitor, Source, Table}
  alias Macaw.Data.Source.{Description, Finish, Request}
  alias Macaw.Data.Source.Conformance.Call

  @doc false
  def check(source, %Description{} = description, o) do
    probes = for ask <- o.requests, budget <- o.budgets, do: {ask, budget}
    pushed = if :push in description.supports and o.push != nil, do: hd(probes)

    for probe <- probes do
      call = {:monitor, probe}

      case Call.run(fn -> run(source, description, probe, probe == pushed, o) end, call, o) do
        {:ok, findings} -> findings
        {:error, fault} -> [fault]
      end
    end
    |> List.flatten()
  end

  defp run(source, description, {ask, budget} = probe, push?, o) do
    fields = ask ++ [budget: budget, viewer: hd(o.viewers)]
    readers = %{reader: [source: :source, ask: fields]}

    with {:ok, monitor} <- faults(probe, Monitor.new(%{source: {source, o.context}}, readers)),
         {:ok, monitor} <- faults(probe, Monitor.tick(monitor, now: 0, at: o.now)) do
      monitor = drained(monitor, 0, 0)
      {:ok, monitor} = Monitor.tick(monitor, now: 1, at: o.now)

      findings =
        case Monitor.status(monitor) do
          %{reader: :live} -> answered(monitor, source, description, probe, fields, o)
          %{reader: status} -> [{:monitor_status, probe, status}]
        end

      findings =
        if push? and findings == [], do: pushed(monitor, source, probe, o), else: findings

      Monitor.stop(monitor)
      findings
    end
  end

  defp faults(_probe, {:ok, monitor}), do: {:ok, monitor}
  defp faults(probe, {:error, faults}), do: [{:monitor_faults, probe, faults}]

  # The reader's delivery against the source's answer finished for it alone.
  defp answered(monitor, source, description, {_ask, budget} = probe, fields, o) do
    {:ok, request} = Request.new(fields ++ [now: o.now])
    got = rows(Monitor.deliveries(monitor).reader)

    with {:ok, fetched} <- Source.fetch(source, description, request),
         {:ok, alone} <- Finish.finish(fetched, description, request),
         {:ok, unreduced} <-
           Finish.finish(fetched, description, %{request | budget: nil, reduce: nil}) do
      expected = rows(alone)
      held = MapSet.new(rows(unreduced))

      cond do
        budget == nil and Enum.sort(got) != Enum.sort(expected) ->
          [{:monitor_rows, probe, length(got), length(expected)}]

        budget != nil and length(got) != length(expected) ->
          [{:monitor_rows, probe, length(got), length(expected)}]

        budget != nil and not Enum.all?(got, &MapSet.member?(held, &1)) ->
          [{:monitor_rows, probe, length(got), length(expected)}]

        true ->
          []
      end
    else
      # A probe the source cannot answer alone is the deliveries check's to report.
      _faults -> []
    end
  end

  # A delivery's rows as the table a monitor holds lays them, so the two compare value
  # for value whatever form the source answered in.
  defp rows(%Delivery{} = delivery) do
    case Delivery.table(delivery) do
      {:ok, table} -> table |> Table.rows() |> elem(1) |> Enum.map(&spelled/1)
      {:error, _faults} -> []
    end
  end

  # A row keyed by its names' strings, as a schema spells them.
  defp spelled(row), do: Map.new(row, fn {key, value} -> {to_string(key), value} end)

  # The source pushed, its messages drained into the monitor and ticked: the reader still
  # live, no error, and more held than before.
  defp pushed(monitor, source, probe, o) do
    before = held_size(monitor)

    case Call.run(fn -> o.push.(source) end, :push, o) do
      {:ok, _any} ->
        monitor = drained(monitor, o.timeout, o.quiet)
        {:ok, monitor} = Monitor.tick(monitor, now: 2, at: o.now)
        status = Monitor.status(monitor).reader
        errors = Monitor.errors(monitor)

        cond do
          status != :live or errors != %{} -> [{:monitor_push, probe, {status, errors}}]
          held_size(monitor) <= before -> [{:monitor_push, probe, :not_held}]
          true -> []
        end

      {:error, fault} ->
        [fault]
    end
  end

  defp held_size(monitor) do
    case Monitor.held(monitor) do
      %{reader: %Delivery{rows: %Table{} = table}} -> Table.size(table)
      _none -> 0
    end
  end

  # Every source message received handed to the monitor: waiting up to `wait` for the
  # first increment, then until `quiet` passes with none.
  defp drained(monitor, wait, quiet) do
    receive do
      {:macaw_source, _ref, message} = received ->
        {:ok, monitor} = Monitor.handle_message(monitor, received)
        next = if match?({:increment, _, _}, message), do: quiet, else: wait
        drained(monitor, next, quiet)
    after
      wait -> monitor
    end
  end
end
